# Introduction
This is a plugin for kong.  

This plugin is used to compose Apis. A compose may means choreography or orchestration.  
Suppose we have two Apis, the first one can get the details of your shoping order according to the order id, but is does not contain the product details. The second Api can get the details of the ordered product according to the order id. Now, we want to get the order detail and ordered product detail by only one called. We can use this plugin to achieve this feature. 

# Development Status
This kong plugin now is under development. And now only support dbless mode.

# Example
kong.yaml
```yaml
_format_version: "1.1"
routes:
- name: test-route
  paths:
  - '/test-api'
  plugins:
  - name: "api-composer"
    route: "test-route"
    config: 
      uri: "/test-api"
      composer_conf: |
        {
          "steps": [
            {
              "name": "step1",
              "type": "http",
              "method": "POST",
              "url": "httpbin/post",
              "inputs": {
                "query": {
                  "key1": {
                    "type": "string",
                    "value": "$.req.query.query_key1"
                  }
                },
                "header": {
                  "X-Test": {
                    "type": "string",
                    "value": "$.req.query.key2"
                  }
                }
              }
            },
            {
              "name": "step2",
              "type": "http",
              "method": "POST",
              "url": "httpbin/post",
              "inputs": {
              }
            },
            {
              "name": "response_name",
              "type": "response",
              "status": 200,
              "outputs": {
                "header": {
                  "X-Res": {
                    "type": "string",
                    "value": "hello"
                  }
                },
                "body": {
                  "type": "object",
                  "properties": {
                    "res_from_step1": {
                      "type": "object",
                      "value": "$.step1.body"
                    }
                  }
                }
              }
            }
          ]
        }
```

then, we can call the api:  
`` curl http://localhost:8000/test-api ``