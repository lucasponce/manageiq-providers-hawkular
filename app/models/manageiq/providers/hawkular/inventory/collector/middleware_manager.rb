require 'hawkular/hawkular_client'

module ManageIQ::Providers
  class Hawkular::Inventory::Collector::MiddlewareManager < ManagerRefresh::Inventory::Collector
    include ::Hawkular::ClientUtils

    SUPPORTED_VERSIONS = %w(WF10 EAP6).freeze

    def connection
      @connection ||= manager.connect
    end

    def resource_tree(resource_id)
      connection.inventory.resource_tree(resource_id)
    end

    def oss
      oss = []
      SUPPORTED_VERSIONS.each do |type|
        oss.concat(resources_for("Platform_Operating System #{type}"))
      end
      oss
    end

    def agents
      agents = []
      SUPPORTED_VERSIONS.each do |type|
        oss.concat(resources_for("Hawkular Java Agent #{type}"))
      end
      agents
    end

    def eaps
      eaps = []
      SUPPORTED_VERSIONS.each do |type|
        eaps.concat(resources_for("WildFly Server #{type}"))
      end
      eaps
    end

    def domain_servers
      domains = []
      SUPPORTED_VERSIONS.each do |type|
        domains.concat(resources_for("Domain WildFly Server #{type}"))
      end
      domains
    end

    def deployments
      deployments = []
      SUPPORTED_VERSIONS.each do |type|
        deployments.concat(resources_for("Deployment #{type}"))
      end
      deployments
    end

    def subdeployments
      subdeployments = []
      SUPPORTED_VERSIONS.each do |type|
        subdeployments.concat(resources_for("SubDeployment #{type}"))
      end
      subdeployments
    end

    def host_controllers
      host_controllers = []
      SUPPORTED_VERSIONS.each do |type|
        host_controllers.concat(resources_for("Host Controller #{type}"))
      end
      host_controllers
    end

    def domains
      domains = []
      SUPPORTED_VERSIONS.each do |type|
        domains.concat(resources_for("Domain Host #{type}"))
      end
      domains
    end

    def domains_from_host_controller(host_controller)
      domains_from_host_controller = []
      SUPPORTED_VERSIONS.each do |type|
        domains_from_host_controller
            .concat(select_domain_controllers(host_controller.children_by_type("Domain Host #{type}")))
      end
      domains_from_host_controller
    end

    def server_groups_from_host_controller(host_controller)
      server_groups = []
      SUPPORTED_VERSIONS.each do |type|
        server_groups.concat(host_controller.children_by_type("Domain Server Group #{type}"))
      end
      server_groups
    end

    def domain_servers_from_host_controller(host_controller)
      domain_servers = []
      SUPPORTED_VERSIONS.each do |type|
        domain_servers.concat(host_controller.children_by_type("Domain WildFly Server #{type}", true))
      end
      domain_servers
    end

    def child_resources(resource_id, recursive = false)
      manager.child_resources(resource_id, recursive)
    end

    def raw_availability_data(metrics, time)
      connection.prometheus.query(:metrics => metrics, :time => time)
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
