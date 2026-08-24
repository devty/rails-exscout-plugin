module Billing
  class InvoiceJob < ApplicationJob
    def perform(order_id)
      Invoice.create!(order: Order.find(order_id))
    end
  end
end
