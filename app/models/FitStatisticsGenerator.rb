class FitStatisticsGenerator
  def self.generate_fit_stats()
    system("source activate lib/envs/amigacondaenv/ && lib/envs/amigacondaenv/bin/python lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt")
    fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', '*_summary.txt'))
    
    fit_stats_paths
  end
  def self.generate_fit_stats_pool(pool_options_string)
    system("source activate lib/envs/amigacondaenv/ && lib/envs/amigacondaenv/bin/python lib/scripts/amigagitsimplified/amiga.py fit -i private/uploads/userexpt --pool-by #{@pool_options_string}")
    fit_stats_paths = Dir.glob(Rails.root.join('private', 'uploads', 'userexpt', 'summary', '*_summary.txt'))
    
    fit_stats_paths
  end
end

