class Shipment < ApplicationRecord
  belongs_to :order

  def quote
    Shipping::RateQuote.for(self)
  end
end
