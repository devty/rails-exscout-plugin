module Billing
  class Invoice < ApplicationRecord
    include Auditable

    belongs_to :order
    has_many :line_items, through: :order
    has_many :payments

    # A bare `Calculator` inside `module Billing` resolves to Billing::Calculator
    # by Ruby's lexical scope rules -- not to some unrelated top-level Calculator.
    def total_cents
      Calculator.new(order).total
    end

    def number
      "INV-#{id}"
    end
  end
end
