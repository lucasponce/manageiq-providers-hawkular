module ManageIQ::Providers
  class Hawkular::Inventory::Persister::MiddlewareManager < ManagerRefresh::Inventory::Persister
    include ManagerRefresh::Inventory::MiddlewareManager

    has_middleware_manager_domains
    has_middleware_manager_server_groups
    has_middleware_manager_servers
    has_middleware_manager_deployments
    has_middleware_manager_datasources
    has_middleware_manager_messagings

    def find_server_group_by_feed_and_name(feed, group_name)
      @server_groups_idx ||= build_server_group_index
      @server_groups_idx.fetch_path(feed, group_name)
    end

    protected

    def build_server_group_index
      idx = {}
      middleware_server_groups.each do |group|
        idx.store_path(group.feed, group.name, group)
      end

      idx
    end
  end
end
