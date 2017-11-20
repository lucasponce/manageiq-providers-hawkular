module ManageIQ::Providers
  class Hawkular::MiddlewareManager::MiddlewareDeployment < MiddlewareDeployment
    AVAIL_TYPE_ID = 'Deployment Status'.freeze
    PARENT_DEPLOYMENT_ID_PROPERTY = 'Parent deployment id'.freeze

    def parent_deployment_id
      ## TODO Check if this property is supported in inventory v4
      properties.try(:[], PARENT_DEPLOYMENT_ID_PROPERTY)
    end

  end
end
