class Order < ApplicationRecord
  include Auditable

  has_many :line_items
  has_many :invoices, class_name: 'Billing::Invoice'
  has_one  :shipment

  # Half of the cycle. Order reaches into Billing for real behaviour, and
  # Billing::InvoicesController reaches back for real behaviour. Neither side
  # moves until one of those directions is inverted.
  def total
    Billing::Calculator.new(self).total
  end
end
