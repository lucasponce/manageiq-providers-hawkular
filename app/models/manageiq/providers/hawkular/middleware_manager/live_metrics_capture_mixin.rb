module ManageIQ::Providers
  module Hawkular::MiddlewareManager::LiveMetricsCaptureMixin
    def metrics_capture
      @metrics_capture ||= ManageIQ::Providers::Hawkular::MiddlewareManager::LiveMetricsCapture.new(self)
    end
  end
end