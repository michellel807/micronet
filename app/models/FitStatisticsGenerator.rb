class FitStatisticsGenerator
  def self.generate_fit_stats()
    Python.exec("lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt")
    fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', '*_summary.txt'))

    fit_stats_paths
  end
  def self.generate_fit_stats_pool()
    Python.exec("lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt --pool-by 'Ribotype,Isolate'")
    fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', '*_summary.txt'))

    fit_stats_paths
  end
end

