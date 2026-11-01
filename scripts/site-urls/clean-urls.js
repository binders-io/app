// CloudFront Function (viewer request, cloudfront-js-2.0) for binders.io. Published by scripts/deploy-site-urls.sh.
//
//   /hub          serves hub.html, and the address stays /hub
//   /help.html    301 to /help (a browser keeps #library across the redirect), with the query string
//   /hub/         301 to /hub
//   /index.html   301 to /
//
// Anything with another extension is left alone, so /appcast.xml, /assets/* and /.well-known/* are never redirected:
// shipped apps' updater reads the feed. It lives outside site/ so that it isn't published with the pages.

// Whole path segments only. "//example.com/x.html" must not match: redirecting it to "//example.com/x" would send
// visitors to another site.
var PAGE = /^((?:\/[A-Za-z0-9_-]+)+)(\.html|\/)?$/;

function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri === '/index.html' || uri === '/index') return redirect('/', request);
  // The error page: asked for by name it has to stay a 404, not a 200 at /404.
  if (uri === '/404.html' || uri === '/404') return request;

  var match = uri.match(PAGE);
  if (!match) return request;
  if (match[2]) return redirect(match[1], request);

  request.uri = uri + '.html';
  return request;
}

function redirect(path, request) {
  return {
    statusCode: 301,
    statusDescription: 'Moved Permanently',
    headers: {
      // A path, not an address, so www.binders.io stays on www.binders.io.
      location: { value: path + queryString(request.querystring) },
      // Short for a 301: browsers keep these, and a wrong one should not outlive a fix by long.
      'cache-control': { value: 'public, max-age=3600' },
    },
  };
}

// CloudFront hands over the values as the viewer sent them, so they go back without encoding them again.
function queryString(querystring) {
  var parts = [];
  Object.keys(querystring || {}).forEach(function (key) {
    var item = querystring[key];
    (item.multiValue || [item]).forEach(function (one) {
      parts.push(key + '=' + one.value);
    });
  });
  return parts.length ? '?' + parts.join('&') : '';
}
