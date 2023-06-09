class FitStatisticsGenerator
  def self.generate_fit_stats()
    system("source activate lib/envs/amigacondaenv/ && lib/envs/amigacondaenv/bin/python lib/scripts/amigagitsimplified/amiga.py fit -i public/uploads/userexpt")
    fit_stats_paths = Dir.glob(Rails.root.join('public', 'uploads', 'userexpt', 'summary', '*_summary.txt'))
    
    fit_stats_paths
  end
end

