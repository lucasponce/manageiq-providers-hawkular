module ManageIQ::Providers
  class Hawkular::Inventory::Persister::MiddlewareManager < ManagerRefresh::Inventory::Persister
    include ManagerRefresh::Inventory::MiddlewareManager

    has_middleware_manager_domains
    has_middleware_manager_server_groups(:secondary_refs => {:by_feed_and_name => %i[feed name]})
    has_middleware_manager_servers
    has_middleware_manager_deployments
    has_middleware_manager_datasources
    has_middleware_manager_messagings
  end
end
