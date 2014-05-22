// Generated by CoffeeScript 1.7.1
var logger;

logger = require('printit')({
  date: true,
  prefix: 'app:error'
});

module.exports = function(err, req, res, next) {
  var header, message, statusCode, templateName, value, _ref;
  if (err instanceof Error) {
    logger.error(err.message);
    logger.error(err.stack);
  }
  statusCode = err.status || 500;
  message = err instanceof Error ? err.message : err.error;
  message = message || 'Server error occurred';
  if ((err.headers != null) && Object.keys(err.headers).length > 0) {
    _ref = err.headers;
    for (header in _ref) {
      value = _ref[header];
      res.set(header, value);
    }
  }
  if ((err.template != null) && (req != null ? req.accepts('html') : void 0) === 'html') {
    templateName = "" + err.template.name + ".jade";
    return res.render(templateName, err.template.params, function(err, html) {
      return res.send(statusCode, html);
    });
  } else {
    return res.send(statusCode, {
      error: message
    });
  }
};