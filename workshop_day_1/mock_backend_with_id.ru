require 'json'

# Получаем порт из переменной окружения или аргумента
port = ENV['PORT'] || '3001'

app = proc do |env|
  path = env['PATH_INFO']

  case path
  when '/health'
    [200, { 'content-type' => 'application/json' },
     [{ status: 'ok', port: port }.to_json]]
  when %r{^/users/\d+$}
    user_id = path.split('/').last
    [200, { 'content-type' => 'application/json' },
     [{
       id: user_id.to_i,
       name: "User #{user_id}",
       served_by: "backend:#{port}"
     }.to_json]]
  else
    [404, { 'content-type' => 'application/json' },
     [{ error: 'not_found' }.to_json]]
  end
end

run app
