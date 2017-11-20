module ManageIQ::Providers
  class Hawkular::MiddlewareManager::MiddlewareMessaging < MiddlewareMessaging
    include ManageIQ::Providers::Hawkular::MiddlewareManager::LiveMetricsCaptureMixin

    def live_metrics_type
      messaging_type
    end

    def chart_report_name
      @chart_report_name ||= if messaging_type.start_with?('JMS Queue')
                               "#{self.class.name.demodulize.underscore}_jms_queue"
                             else
                               "#{self.class.name.demodulize.underscore}_jms_topic"
                             end
    end

    def chart_layout_path
      @chart_layout_path ||= if messaging_type.start_with?('JMS Queue')
                               "#{self.class.name.demodulize}_jms_queue"
                             else
                               "#{self.class.name.demodulize}_jms_topic"
                             end
    end
  end
end
