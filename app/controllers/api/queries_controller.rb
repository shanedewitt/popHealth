require 'cypress/record_filter.rb'
require 'cypress/cat_3_calculator.rb'

module Api
  class QueriesController < ApplicationController
    resource_description do
      short 'Queries'
      formats ['json']
      description <<-QCDESC
        This resource is responsible for managing clinical quality measure calculations. Creating a new query will kick
        off a new CQM calculation (if it hasn't already been calculated). You can determine the status of ongoing
        calculations, force recalculations and see results through this resource.
      QCDESC
    end
    include PaginationHelper
    include LogsHelper
    skip_authorization_check
    before_filter :authenticate_user!
    before_filter :set_pagination_params, :only => [:patient_results, :patients]

    def self.get_svs_value(key, cval)
      id = cval[:id]
      code=cval[:code]
      return code if ! code.nil?
      val = $mongo_client.database.collection('health_data_standards_svs_value_sets')
                .find({"concepts._id": BSON::ObjectId("#{id}")}).projection({"concepts.$": 1}).first
      if !val.nil?
        val['concepts'][0]['code']
      elsif !cval[:code].nil?
        val = $mongo_client.database.collection('health_data_standards_svs_value_sets')
                  .find({"concepts.code": cval[:code]}).projection({"concepts.$": 1}).first
        val['concepts'][0]['code'] unless val.nil?
      else
        puts "id or code not found"
      end
    end

    @@filter_mapping = {
        'ethnicities' => method(:get_svs_value),
        'races' => method(:get_svs_value),
        'payers' => method(:get_svs_value),
        'problems' => Proc.new{ |key, cval|
          id=cval[:id]
          val = $mongo_client.database.collection('health_data_standards_svs_value_sets').find("_id" => BSON::ObjectId("#{id}")).first
          val['oid'] if not val.nil?
        },
        'providerTypes' => method(:get_svs_value),
        'age' => Proc.new { |key, txt|
          res={}
          m = /(>=?)\s*(\d+)/.match(txt) or /(<=?)\s*(\d+)/.match(txt)
          unless m.nil?
            n=m[2].to_i # to_i?
            case m[1]
              when '<'
                res['max'] = n-1
              when '<='
                res['max'] = n
              when '>'
                res['min'] = n+1
              when '>='
                res['min'] = n
            end
            # ruby is SOOO baroque
            next res
          end
          # OR
          m= /^\s*(\d+)\s*-+\s*(\d+)/.match(txt)
          unless m.nil?
            res['min'] = m[1]
            res['max'] = m[2]
            next res
          end
          puts "ERROR: Bad input to age:#{txt}"
        },
        #     :gender => Patient,
        # 'problems' => Proc.new { |key, id|
        #   res=[]
        #   val = $mongo_client.database.collection('health_data_standards_svs_value_sets')
        #             .find({_id: BSON::ObjectId("#{id}")}).first
        #   if not val.nil?
        #     val['concepts'].each do |v|
        #       res.push(v['code'])
        #     end
        #   end
        #   res
        # }
        # npis =>
        #     :tin => Provider,
        #     :providerType => Provider,
        #     :address => Provider
    }


    def index
      filter = {}
      filter["hqmf_id"] = {"$in" => params["measure_ids"]} if params["measure_ids"]
      providers = collect_provider_id
      filter["filters.providers"] = {"$in" => providers} if providers
      log_api_call LogAction::VIEW, "View all queries"
      render json: QME::QualityReport.where(filter)
    end

    api :GET, '/queries/:id', "Retrieve clinical quality measure calculation"
    param :id, String, :desc => 'The id of the quality measure calculation', :required => true
    example '{"DENEX":0,"DENEXCEP":0,"DENOM":5,"IPP":5,"MSRPOPL":0,"NUMER":0,  "status":{"state":"completed", ...}, ...}'
    description "Gets a clinical quality measure calculation. If calculation is completed, the response will include the results."

    def show
      @qr = QME::QualityReport.find(params[:id])

      if current_user.preferences.show_aggregate_result && !@qr.aggregate_result && !APP_CONFIG['use_opml_structure']
        cv = @qr.measure.continuous_variable
        aqr = QME::QualityReport.where(measure_id: @qr.measure_id, sub_id: @qr.sub_id, 'filters.providers' => [Provider.root._id.to_s], effective_date: @qr.effective_date).first
        if aqr.result
          if cv
            @qr.aggregate_result = aqr.result.OBSERV
          else
            @qr.aggregate_result = (aqr.result.DENOM > 0) ? (100*((aqr.result.NUMER).to_f / (aqr.result.DENOM - aqr.result.DENEXCEP - aqr.result.DENEX).to_f)).round : 0
          end
          @qr.save!
        end
      end

      log_api_call LogAction::VIEW, "View quality measure calculation"
      authorize! :read, @qr
      render json: @qr
    end

    api :POST, '/queries', "Start a clinical quality measure calculation"
    param :measure_id, String, :desc => 'The HQMF id for the CQM to calculate', :required => true
    param :sub_id, String, :desc => 'The sub id for the CQM to calculate. This is popHealth specific.', :required => false, :allow_nil => true
    param :effective_date, ->(effective_date) { effective_date.present? }, :desc => 'Time in seconds since the epoch for the end date of the reporting period', :required => true
    param :effective_start_date, ->(effective_start_date) { effective_start_date.present? }, :desc => 'Time in seconds since the epoch for the start date of the reporting period'
    param :providers, Array, :desc => 'An array of provider IDs to filter the query by', :allow_nil => true
    example '{"_id":"52fe409bb99cc8f818000001", "status":{"state":"queued", ...}, ...}'
    description <<-CDESC
      This action will create a clinical quality measure calculation. If the measure has already been calculated,
      it will return the results. If not, it will return the status of the calculation, which can be checked in
      the status property of the returned JSON. If it is calculating, then the results may be obtained by the
      GET action with the id.
    CDESC

    def create
      options = {}
      options[:filters] = build_filter

      authorize_providers
      end_date = params[:effective_date]
      start_date = params[:effective_start_date]

      end_date = Time.at(end_date.to_i) if end_date.is_a?(String)
      start_date = Time.at(start_date.to_i) if start_date.is_a?(String)

      start_date = end_date.years_ago(1) if start_date.nil?

      rp = ReportingPeriod.where(start_date: start_date, end_date: end_date).first_or_create
      rp.save!

      options[:start_date] = start_date
      options[:effective_date] = end_date
      options[:test_id] = rp._id
      options['prefilter'] = build_mr_prefilter if APP_CONFIG['use_map_reduce_prefilter']

      qr = QME::QualityReport.find_or_create(params[:measure_id],
                                             params[:sub_id], options)
      if !qr.calculated?
        qr.calculate({"oid_dictionary" => OidHelper.generate_oid_dictionary(qr.measure),
                      "enable_rationale" => APP_CONFIG['enable_map_reduce_rationale'] || false,
                      "enable_logging" => APP_CONFIG['enable_map_reduce_logging'] || false}, true)
      end

      if current_user.preferences.show_aggregate_result && !APP_CONFIG['use_opml_structure']
        agg_options = options.clone
        agg_options[:filters][:providers] = [Provider.root._id.to_s]
        aqr = QME::QualityReport.find_or_create(params[:measure_id],
                                                params[:sub_id], agg_options)
        if !aqr.calculated?
          aqr.calculate({"oid_dictionary" => OidHelper.generate_oid_dictionary(aqr.measure),
                         "enable_rationale" => APP_CONFIG['enable_map_reduce_rationale'] || false,
                         "enable_logging" => APP_CONFIG['enable_map_reduce_logging'] || false}, true)
        end
      end

      log_api_call LogAction::ADD, "Create a clinical quality calculation"
      render json: qr
    end

    api :DELETE, '/queries/:id', "Remove clinical quality measure calculation"
    param :id, String, :desc => 'The id of the quality measure calculation', :required => true

    def destroy
      qr = QME::QualityReport.find(params[:id])
      authorize! :delete, qr
      qr.destroy
      log_api_call LogAction::DELETE, "Remove clinical quality calculation"
      render :status => 204, :text => ""
    end

    api :PUT, '/queries/:id/recalculate', "Force a clinical quality measure to recalculate"
    param :id, String, :desc => 'The id of the quality measure calculation', :required => true

    def recalculate
      qr = QME::QualityReport.find(params[:id])
      authorize! :recalculate, qr
      qr.calculate({"oid_dictionary" => OidHelper.generate_oid_dictionary(qr.measure_id),
                    'recalculate' => true}, true)
      log_api_call LogAction::UPDATE, "Force a clinical quality calculation"
      render json: qr
    end


    def resolveGender

    end

    def resolveAge

    end

    api :POST, '/queries/:id/filter', "Apply a filter to an existing measure calculation"
    param :id, String, :desc => 'The id of the quality measure calculation', :required => true

    def filter
      lastqc=nil
      filters={}
      #QME::QualityReport.where(measure_id: params[:id]).each do |qc|
      #authorize! :recalculate, qc
      # add filters here
      params.each_pair do |key, val|
        if not /^(controller|action|id)/i === key
          (0...val.length).each do |i|
            value =val[i] || val[i.to_s]
            if /npis|tins/i === key
              key='provider_ids'
              value=value[:id]
            end
            filters[key] = [] if filters[key].nil?
            if @@filter_mapping[key]
              # and why does the array come through sometimes with ['0'] instead of [0]
              filters[key].push(@@filter_mapping[key].call(key, value))
              next # wish TF we had continue
            end

            if key == 'problems'
              filters[key].push(:oid => res)
              next
            end

            if value.is_a?(Array)
              filters[key].concat(value)
            else
              filters[key].push(value)
            end
          end
        end
      end
      #now do something with filters
      # todo: Date.new should be replaced by meaningful
      # todo: :bundle_id in options Is there only ever one bundle
      bundle=Bundle.first
      pcache = PatientCache.first
      mrns = []
      records = Cypress::RecordFilter.filter(Record, filters, {
          :effective_date => pcache ? pcache['value']['effective_date'] : bundle.effective_date, :bundle_id => bundle._id})
      numrecs = records.count rescue nil
      unless numrecs.nil?
        reset_patient_cache
        records.each do |r|
          if PatientCache.where("value.medical_record_id": r['medical_record_number']).exists?
            mrns.push(r.medical_record_number)
          end
        end
        # At this point the mrns tell us what cat1's to keep and what cat3's to generate

        PatientCache.not_in("value.medical_record_id" => mrns).destroy_all
        # do everything
        # what to do if there are no candidates after a filter? make empty zips?
        render json: paginate(patient_results_api_query_url(),
                              PatientCache.where(build_patient_filter).only(
                                  '_id', 'value.medical_record_id', 'value.first', 'value.last', 'value.birthdate',
                                  'value.gender', 'value.patient_id'))
      else
        render json:{}
      end
      #qc.calculate({"oid_dictionary" => OidHelper.generate_oid_dictionary(qc.measure_id),
      #            'recalculate' => true}, true)
    end

    def reset_patient_cache
      pcache =$mongo_client.database.collection('patient_cache')
      backup= $mongo_client.database.collection(:patient_cache_bak);
      if backup.count > pcache.count
        # restore to patient_cache
        pcache.drop()
        $mongo_client.database.collection(:patient_cache).insert_many(backup.find({}).to_a)
      end
      backup.drop() #backup.find({}).delete_many
      backup.insert_many($mongo_client.database.collection('patient_cache').find({}).to_a)
    end

    #if lastqc
    #      render json: paginate(patient_results_api_query_url(lastqc),
    #                             lastqc.patient_results.where(build_patient_filter).only('_id', 'value.medical_record_id',
    #                                                                                     'value.first', 'value.last', 'value.birthdate',
    #                                                                                     'value.gender', 'value.patient_id'))
    #     end


    api :GET, '/queries/:id/patient_results[?population=true|false]',
        "Retrieve patients relevant to a clinical quality measure calculation"
    param :id, String, :desc => 'The id of the quality measure calculation', :required => true
    param :ipp, /true|false/, :desc => 'Ensure patients meet the initial patient population for the measure', :required => false
    param :denom, /true|false/, :desc => 'Ensure patients meet the denominator for the measure', :required => false
    param :numer, /true|false/, :desc => 'Ensure patients meet the numerator for the measure', :required => false
    param :denex, /true|false/, :desc => 'Ensure patients meet the denominator exclusions for the measure', :required => false
    param :denexcp, /true|false/, :desc => 'Ensure patients meet the denominator exceptions for the measure', :required => false
    param :msrpopl, /true|false/, :desc => 'Ensure patients meet the measure population for the measure', :required => false
    param :antinumerator, /true|false/, :desc => 'Ensure patients are not in the numerator but are in the denominator for the measure', :required => false
    param_group :pagination, Api::PatientsController
    example '[{"_id":"52fe409ef78ba5bfd2c4127f","value":{"DENEX":0,"DENEXCEP":0,"DENOM":1,"IPP":1,"NUMER":1,"antinumerator":0,"birthdate":1276869600.0,"effective_date":1356998340.0,,"first":"Steve","gender":"M","last":"E","measure_id":"40280381-3D61-56A7-013E-6224E2AC25F3","medical_record_id":"ce83c561f62e245ad4e0ca648e9de0dd","nqf_id":"0038","patient_id":"52fbbf34b99cc8a728000068"}},...]'
    description <<-PRDESC
      This action returns an array of patients that have results calculated for this clinical quality measure. The list can be restricted
      to specific populations, such as only patients that have made it into the numerator by passing in a query parameter for a particular
      population. Results are paginated.
    PRDESC

    def patient_results
      qr = QME::QualityReport.find(params[:id])
      authorize! :read, qr
      # this returns a criteria object so we can filter it additionally as needed
      results = qr.patient_results
      log_api_call LogAction::VIEW, "Get patient results for measure calculation", true
      render json: paginate(patient_results_api_query_url(qr), results.where(build_patient_filter).only('_id', 'value.medical_record_id', 'value.first', 'value.last', 'value.birthdate', 'value.gender', 'value.patient_id'))
    end

    def patients
      qr = QME::QualityReport.find(params[:id])
      authorize! :read, qr
      # this returns a criteria object so we can filter it additionally as needed
      results = qr.patient_results
      ids = paginate(patients_api_query_url(qr), results.where(build_patient_filter).order_by([:last.asc, :first.asc])).collect { |r| r["value.medical_record_id"] }
      log_api_call LogAction::VIEW, "Get patients for measure calculation", true
      render :json => Record.where({:medical_record_number.in => ids})
    end


    private
    def build_filter
      @filter = params.select { |k, v| %w(providers).include? k }.to_options
    end

    def authorize_providers
      providers = @filter[:providers] || []
      if !providers.empty?
        providers.each do |p|
          provider = Provider.find(p)
          authorize! :read, provider
        end
      else
        #this is hacky and ugly but cancan will allow just the
        # class Provider to pass for a simple user so providing
        #an empty Provider with no NPI number gets around this
        authorize! :read, Provider.new
      end
    end

    def build_mr_prefilter
      measure = HealthDataStandards::CQM::Measure.where({"hqmf_id" => params[:measure_id], "sub_id" => params[:sub_id]}).first
      measure.prefilter_query!(params[:effective_date].to_i)
      measure.prefilter_query!(params[:effective_start_date].to_i)
    end

    def build_patient_filter
      patient_filter = {}
      patient_filter["value.IPP"]= {"$gt" => 0} if params[:ipp] == "true"
      patient_filter["value.DENOM"]= {"$gt" => 0} if params[:denom] == "true"
      patient_filter["value.NUMER"]= {"$gt" => 0} if params[:numer] == "true"
      patient_filter["value.DENEX"]= {"$gt" => 0} if params[:denex] == "true"
      patient_filter["value.DENEXCEP"]= {"$gt" => 0} if params[:denexcep] == "true"
      patient_filter["value.MSRPOPL"]= {"$gt" => 0} if params[:msrpopl] == "true"
      patient_filter["value.antinumerator"]= {"$gt" => 0} if params[:antinumerator] == "true"
      patient_filter["value.provider_performances.provider_id"]= BSON::ObjectId.from_string(params[:provider_id]) if params[:provider_id]
      patient_filter
    end

    def collect_provider_id
      params[:providers] || Provider.where({:npi.in => params[:npis] || []}).to_a
    end
  end
end
