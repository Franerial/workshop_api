require 'json'

app = proc do |env|
  path = env['PATH_INFO']
  method = env['REQUEST_METHOD']

  response = case [method, path]
  when ['GET', '/health']
    { status: 'ok', service: 'users' }
  when ['GET', '/users/1']
    { id: 1, name: 'John Doe', email: 'john@example.com' }
  when ['GET', '/users/2']
    { id: 2, name: 'Jane Doe', email: 'jane@example.com' }
  else
    [404, { 'content-type' => 'application/json' },
     [{ error: 'not_found', message: 'Resource not found' }.to_json]]
  end

  if response.is_a?(Hash)
    [200, { 'content-type' => 'application/json' }, [response.to_json]]
  else
    response
  end
end

run app
