require 'hawkular/hawkular_client'

module ManageIQ::Providers
  class Hawkular::Inventory::Collector::MiddlewareManager < ManagerRefresh::Inventory::Collector
    include ::Hawkular::ClientUtils

    def connection
      @connection ||= manager.connect
    end

    def resource_tree(resource_id)
      connection.inventory.resource_tree(resource_id)
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

    def domain_servers
      resources_for('Domain WildFly Server')
    end

    def deployments
      resources_for('Deployment')
    end

    def subdeployments
      resources_for('SubDeployment')
    end

    def host_controllers
      resources_for('Host Controller')
    end

    def domains
      select_domain_controllers(resources_for('Domain Host'))
    end

    def domains_from_host_controller(host_controller)
      select_domain_controllers(host_controller.children_by_type('Domain Host'))
    end

    def server_groups_from_host_controller(host_controller)
      host_controller.children_by_type('Domain Server Group')
    end

    def domain_servers_from_host_controller(host_controller)
      host_controller.children_by_type('Domain WildFly Server', true)
    end

    def child_resources(resource_id, recursive = false)
      manager.child_resources(resource_id, recursive)
    end

    def raw_availability_data(*args)
      connection.metrics.avail.raw_data(*args)
    end

    private

    def resources_for(resource_type)
      connection.inventory.resources_for_type(resource_type)
    end

    def select_domain_controllers(domains)
      domains.select { |host| host.config['Is Domain Controller'] == 'true' }
    end
  end
end
