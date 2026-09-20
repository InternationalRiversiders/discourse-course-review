DiscourseCourseReview::Engine.routes.draw do
  get "/" => "main#index"
  get "/state" => "main#state"
  get "/export" => "main#export"
  get "/legacy" => "main#legacy"
  get "/legacy/*path" => "main#legacy"
  post "/action" => "main#mutate"
end
