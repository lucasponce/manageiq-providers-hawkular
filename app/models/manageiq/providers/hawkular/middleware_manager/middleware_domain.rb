module ManageIQ::Providers
  class Hawkular::MiddlewareManager::MiddlewareDomain < MiddlewareDomain
    AVAIL_TYPE_ID = 'Domain Availability'.freeze

    def properties
      self.properties = super || {}
    end

    def availability
      properties['Availability']
    end

    def availability=(value)
      properties['Availability'] = value
    end
  end
end
