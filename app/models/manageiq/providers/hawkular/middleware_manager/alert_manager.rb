module ManageIQ::Providers
  class Hawkular::MiddlewareManager::AlertManager
    require 'hawkular/hawkular_client'

    def initialize(ems)
      @ems = ems
      @alerts_client = ems.alerts_client
    end

    def process_alert(operation, miq_alert)
      group_trigger = convert_to_group_trigger(operation, miq_alert)
      group_conditions = convert_to_group_conditions(miq_alert)

      case operation
      when :new
        @alerts_client.create_group_trigger(group_trigger)
        @alerts_client.set_group_conditions(group_trigger.id,
                                            :FIRING,
                                            group_conditions)
      when :update
        @alerts_client.update_group_trigger(group_trigger)
        @alerts_client.set_group_conditions(group_trigger.id,
                                            :FIRING,
                                            group_conditions)
      when :delete
        @alerts_client.delete_group_trigger(group_trigger.id)
      end
    end

    def self.build_hawkular_trigger_id(ems:, alert:)
      ems.miq_id_prefix("alert-#{extract_alert_id(alert)}")
    end

    def self.resolve_hawkular_trigger_id(ems:, alert:, alerts_client: nil)
      alerts_client = ems.alerts_client unless alerts_client
      trigger_id = build_hawkular_trigger_id(:ems => ems, :alert => alert)

      if alerts_client.list_triggers([trigger_id]).blank?
        trigger_id = "MiQ-#{extract_alert_id(alert)}"
      end

      trigger_id
    end

    private

    def build_hawkular_trigger_id(alert)
      self.class.build_hawkular_trigger_id(:ems => @ems, :alert => alert)
    end

    def resolve_hawkular_trigger_id(alert)
      self.class.resolve_hawkular_trigger_id(:ems => @ems, :alert => alert, :alerts_client => @alerts_client)
    end

    def self.extract_alert_id(alert)
      case alert
      when Hash
        alert[:id]
      when Numeric
        alert
      else
        alert.id
      end
    end

    private_class_method :extract_alert_id

    def convert_to_group_trigger(operation, miq_alert)
      trigger_id = if operation == :new
                     build_hawkular_trigger_id(miq_alert)
                   else
                     resolve_hawkular_trigger_id(miq_alert)
                   end

      ::Hawkular::Alerts::Trigger.new('id'          => trigger_id,
                                      'name'        => miq_alert[:description],
                                      'description' => miq_alert[:description],
                                      'enabled'     => miq_alert[:enabled],
                                      'type'        => :GROUP,
                                      'eventType'   => :EVENT,
                                      'tags'        => {
                                        'miq.event_type'    => 'hawkular_alert',
                                        'miq.resource_type' => miq_alert[:based_on],
                                        'prometheus'        => 'unused_value'
                                      })
    end

    def convert_to_group_conditions(miq_alert)
      eval_method = miq_alert[:conditions][:eval_method]
      options = miq_alert[:conditions][:options]
      case eval_method
      when "mw_accumulated_gc_duration" then
        generate_mw_gc_condition(options)
      when "mw_heap_used", "mw_non_heap_used" then
        generate_mw_jvm_conditions(options)
      when *MW_DATASOURCE then
        generate_mw_generic_threshold_conditions(options, mw_datasource_metrics_by_column[eval_method])
      when *MW_MESSAGING then
        generate_mw_generic_threshold_conditions(options, mw_messaging_metrics_by_column[eval_method])
      when *MW_WEB_SESSIONS then
        generate_mw_generic_threshold_conditions(options, mw_server_metrics_by_column[eval_method])
      when *MW_TRANSACTIONS then
        generate_mw_generic_threshold_conditions(options, mw_server_metrics_by_column[eval_method])
      end
    end

    def mw_server_metrics_by_column
      MiddlewareServer.live_metrics_config['supported_metrics']['default'].invert
    end

    def mw_datasource_metrics_by_column
      MiddlewareDatasource.live_metrics_config['supported_metrics']['default'].invert
    end

    def mw_messaging_metrics_by_column
      all = {}
      supported_metrics = MiddlewareMessaging.live_metrics_config['supported_metrics']
      supported_metrics.keys.each { |resource_type|
        type_metrics = supported_metrics[resource_type]
        all.merge!( supported_metrics[resource_type].invert ) if type_metrics
      }
      all
    end

    def generate_mw_gc_condition(options)
      c = ::Hawkular::Alerts::Trigger::Condition.new({})
      c.trigger_mode = :FIRING
      c.type = :EXTERNAL
      c.alerter_id = 'prometheus'
      c.data_id = 'group_data_id'

      operator = options[:mw_operator]
      # metrics is in seconds, so convert ms to s
      threshold = options[:value_mw_garbage_collector].to_i / 1000.0
      expression = 'sum(delta($FAMILY_TS(Accumulated GC Duration)[1m]))'
      c.expression = "#{expression} #{operator} #{threshold}"

      ::Hawkular::Alerts::Trigger::GroupConditionsInfo.new([c])
    end

    def generate_mw_jvm_conditions(options)
      c = ::Hawkular::Alerts::Trigger::Condition.new({})
      c.trigger_mode = :FIRING
      c.type = :EXTERNAL
      c.alerter_id = 'prometheus'
      c.data_id = 'group_data_id'

      gt = options[:value_mw_greater_than].to_f / 100
      lt = options[:value_mw_less_than].to_f / 100
      expression = "$TS(Heap Used)/$TS(Heap Max)"
      gt_expression = "(#{expression} > #{gt})"
      lt_expression = "(#{expression} < #{lt})"
      c.expression = "#{gt_expression} OR #{lt_expression}"
      ::Hawkular::Alerts::Trigger::GroupConditionsInfo.new([c])
    end

    def generate_mw_generic_threshold_conditions(options, metric)
      ::Hawkular::Alerts::Trigger::GroupConditionsInfo.new(
        [
          generate_mw_threshold_condition(
            metric,
            options[:mw_operator],
            options[:value_mw_threshold].to_i
          )
        ]
      )
    end

    def generate_mw_threshold_condition(metric, operator, threshold)
      c = ::Hawkular::Alerts::Trigger::Condition.new({})
      c.trigger_mode = :FIRING
      c.type = :EXTERNAL
      c.alerter_id = 'prometheus'
      c.data_id = 'group_data_id'
      c.expression = "$TS(#{metric}) #{operator} #{threshold}"
      c
    end

    MW_WEB_SESSIONS = %w(
      mw_aggregated_active_web_sessions
      mw_aggregated_expired_web_sessions
      mw_aggregated_rejected_web_sessions
    ).freeze

    MW_DATASOURCE = %w(
      mw_ds_available_count
      mw_ds_in_use_count
      mw_ds_timed_out
      mw_ds_average_get_time
      mw_ds_average_creation_time
      mw_ds_max_wait_time
    ).freeze

    MW_MESSAGING = %w(
      mw_ms_topic_delivering_count
      mw_ms_topic_durable_message_count
      mw_ms_topic_non_durable_message_count
      mw_ms_topic_message_count
      mw_ms_topic_message_added
      mw_ms_topic_durable_subscription_count
      mw_ms_topic_non_durable_subscription_count
      mw_ms_topic_subscription_count
    ).freeze

    MW_TRANSACTIONS = %w(
      mw_tx_committed
      mw_tx_timeout
      mw_tx_heuristics
      mw_tx_application_rollbacks
      mw_tx_resource_rollbacks
      mw_tx_aborted
    ).freeze
  end
end
