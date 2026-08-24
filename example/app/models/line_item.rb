class LineItem < ApplicationRecord
  belongs_to :order

  def extended_price
    unit_price * quantity
  end
end
