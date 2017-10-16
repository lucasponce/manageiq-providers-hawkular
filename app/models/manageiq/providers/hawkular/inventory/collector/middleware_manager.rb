require 'hawkular/hawkular_client'

module ManageIQ::Providers
  class Hawkular::Inventory::Collector::MiddlewareManager < ManagerRefresh::Inventory::Collector
    include ::Hawkular::ClientUtils

    def connection
      @connection ||= manager.connect
    end

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

    def resources_for(resource_type)
      connection.inventory_v4.resources_for_type(resource_type)
    end
  end
end
