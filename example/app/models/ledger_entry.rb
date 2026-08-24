# A top-level constant that belongs to Billing. Nothing in the name says so,
# which is the whole reason .extract-scout/domains.json has to exist -- namespace
# inference alone cannot place this file.
#
# This is the file the cross-domain hook demo edits.
class LedgerEntry < ApplicationRecord
  include Auditable

  def self.record(invoice)
    create!(amount_cents: invoice.total_cents, reference: invoice.number)
  end
end
