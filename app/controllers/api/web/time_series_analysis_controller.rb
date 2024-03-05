class Api::Web::TimeSeriesAnalysisController < ApplicationController
  include TimeSeriesAnalyser

  def create
    data = time_series_analysis_params[:time_series].split(',').map{|elm|elm.to_i}
    tolerance_diff_distance = time_series_analysis_params[:tolerance_diff_distance].to_d

    clustered_subsequences, reached_to_max_window_size = clustering_subsequences_all_timeseries(data, tolerance_diff_distance)
    render json: {
      clusteredSubsequences: clustered_subsequences,
      timeSeries: [['index', 'allValue']] + data.map.with_index{|elm, index|[index.to_s, elm]},
      reachedToMaxWindowSize: reached_to_max_window_size
    }
  end

  private  
    def time_series_analysis_params
      params.require(:time_series_analysis).permit(
        :time_series,
        :tolerance_diff_distance
      )
    end

end
