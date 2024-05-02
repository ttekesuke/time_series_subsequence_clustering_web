class Api::Web::TimeSeriesController < ApplicationController
  include TimeSeriesAnalyser

  def analyse
    data = analyse_params[:time_series].split(',').map{|elm|elm.to_i}
    tolerance_diff_distance = analyse_params[:tolerance_diff_distance].to_d

    clustered_subsequences = clustering_subsequences_incremental(data, tolerance_diff_distance)
    render json: {
      clusteredSubsequences: clustered_subsequences,
      timeSeries: [['index', 'allValue']] + data.map.with_index{|elm, index|[index.to_s, elm]},
    }
  end

  def generate
    data = generate_params[:complexity_transition].split(',').map{|elm|elm.to_i}
    p data
  end

  private  
    def analyse_params
      params.require(:analyse).permit(
        :time_series,
        :tolerance_diff_distance
      )
    end
    
    def generate_params
      params.require(:generate).permit(
        :complexity_transition,
      )
    end

end
