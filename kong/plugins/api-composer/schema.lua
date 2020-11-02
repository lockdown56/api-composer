return {
  name = "api-composer",
  fields = {
    { config = {
        type = "record",
        fields = {
          { uri = {type = "string", required = true} },
          { composer_conf = { type = "string", required = true } }
        }
      },
    },
  }
}
