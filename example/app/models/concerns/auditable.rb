# Lives at app/models/concerns/auditable.rb and defines Auditable -- NOT
# Concerns::Auditable. Rails registers app/*/concerns as an autoload root in its
# own right, and a tool that gets this wrong orphans every concern in the app.
module Auditable
  extend ActiveSupport::Concern

  included do
    has_many :audit_events, as: :auditable
  end

  def audit!(action)
    AuditEvent.create!(auditable: self, action: action)
  end
end
