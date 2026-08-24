module Billing
  class InvoicesController < ApplicationController
    # The other half of the cycle: Billing reaching back into Order.
    def create
      order = Order.find(params[:order_id])
      @invoice = Invoice.create!(order: order)
      LedgerEntry.record(@invoice)
    end
  end
end
