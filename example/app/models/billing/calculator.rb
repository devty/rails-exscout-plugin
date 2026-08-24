module Billing
  class Calculator
    def initialize(order)
      @order = order
    end

    def total
      subtotal + TaxEngine.for(@order).amount
    end

    def subtotal
      @order.line_items.sum(&:extended_price)
    end
  end
end
