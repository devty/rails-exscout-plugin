module Billing
  class TaxEngine
    def self.for(order)
      new(order)
    end

    def initialize(order)
      @order = order
    end

    def amount
      (order_subtotal * 0.0875).round
    end

    private

    def order_subtotal
      @order.line_items.sum(&:extended_price)
    end
  end
end
