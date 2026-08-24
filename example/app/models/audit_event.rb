# `belongs_to :auditable, polymorphic: true` names an interface, not a class.
# There is no Auditable model to point an edge at; the implementers are whichever
# models declare `as: :auditable`, which is a fact spread across other files.
class AuditEvent < ApplicationRecord
  belongs_to :auditable, polymorphic: true
end
