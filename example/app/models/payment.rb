# Payment and Billing::Invoice reference each other, and it is NOT a cycle.
# `belongs_to` on one side plus `has_many` on the other is one relationship
# declared from both ends -- the standard Rails idiom, present in every app.
# A tool that counts it as bidirectional coupling reports a blocker in an app
# that has none.
class Payment < ApplicationRecord
  belongs_to :invoice, class_name: 'Billing::Invoice'

  def settled?
    captured_at.present?
  end
end
