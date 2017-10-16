require 'hawkular/hawkular_client'

module ManageIQ::Providers
  class Hawkular::Inventory::Collector::MiddlewareManager < ManagerRefresh::Inventory::Collector
    include ::Hawkular::ClientUtils

    def connection
      @connection ||= manager.connect
    end

    # def feeds
    #  connection.inventory.list_feeds
    # end

    def resource_tree(resource_id)
      connection.inventory_v4.resource_tree(resource_id)
    end

    def oss
      resources_for('Platform_Operating System')
    end

    def agents
      resources_for('Hawkular WildFly Agent')
    end

    def eaps
      resources_for('WildFly Server')
    end

    def host_controllers
      resources_for('Host Controller')
    end

    def domains(host_controller)
      host_controller.children_by_type('Domain Host')
        .select { true } #|host| host.properties['Is Domain Controller'] == 'true' }
    end

    def server_groups(host_controller)
      host_controller.children_by_type('Domain Server Group')
    end

    def domain_servers(host_controller)
      host_controller.children_by_type('Domain WildFly Server', true)
    end

    def child_resources(resource_id, recursive = false)
      manager.child_resources(resource_id, recursive)
    end

    def machine_id(feed)
      os_property_for(feed, 'Machine Id')
    end

    def container_id(feed)
      os_property_for(feed, 'Container Id')
    end

    def config_data_for_resource(resource_path)
      connection.inventory.get_config_data_for_resource(resource_path)
    end

    def metrics_for_metric_type(feed, metric_type_id)
      metric_type_path = ::Hawkular::Inventory::CanonicalPath.new(
        :metric_type_id => metric_type_id, :feed_id => feed
      )
      connection.inventory.list_metrics_for_metric_type(metric_type_path)
    end

    def raw_availability_data(*args)
      connection.metrics.avail.raw_data(*args)
    end

    private

    def os_property_for(feed, property)
      os_resource_for(feed)
        .try(:properties)
        .try { |prop| prop[property] }
    end

    def os_resource_for(feed)
      os_for(feed)
        .try { |os| connection.inventory.list_resources_for_type(os.path, true) }
        .presence
        .try(:first)
    end

    def os_for(feed)
      connection
        .inventory
        .list_resource_types(feed)
        .find { |item| item.id.include? 'Operating System' }
    end

    def resources_for(resource_type)
      connection.inventory_v4.resources_for_type(resource_type)
    end
  end
end
