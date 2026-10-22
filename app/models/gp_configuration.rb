class GpConfiguration
  def self.filters(source)
    if source[:gp_subset_filters]
      raw = source[:gp_subset_filters]
      rows = raw.respond_to?(:each_pair) ? raw.values : Array(raw)
      rows.map do |filter|
        filter = filter.to_unsafe_h if filter.respond_to?(:to_unsafe_h)
        filter = filter.with_indifferent_access
        { "column" => filter[:column].to_s, "values" => Array(filter[:values]).reject(&:blank?).uniq }
      end
    else
      [{ "column" => source[:gp_subset_column].to_s, "values" => Array(source[:gp_conditions]).reject(&:blank?) }]
    end
  end

  def self.pool_columns(source)
    return [] if source[:gp_pool_replicates] == "no"

    if source[:gp_pool_columns]
      Array(source[:gp_pool_columns]).reject(&:blank?).uniq
    else
      source[:gp_pool_by_column].to_s.split(",").reject { |column| column.blank? || column == "None" }
    end
  end

  def self.subset_description(source)
    filters(source).map { |filter| "#{filter['column']}: #{filter['values'].join(', ')}" }.join("; ")
  end

  def self.subset_argument(source)
    filters(source).map { |filter| "#{filter['column']}:#{filter['values'].join(',')}" }.join(";")
  end
end
