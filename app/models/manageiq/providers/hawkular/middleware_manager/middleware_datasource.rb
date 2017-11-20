module ManageIQ::Providers
  class Hawkular::MiddlewareManager::MiddlewareDatasource < MiddlewareDatasource
    include ManageIQ::Providers::Hawkular::MiddlewareManager::LiveMetricsCaptureMixin
  end
end
