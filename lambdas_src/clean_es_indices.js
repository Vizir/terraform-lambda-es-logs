const https = require('https');
const aws4 = require('./aws4');
const { DateTime, Duration } = require('./luxon');
const { INDEX_NAME_PATTERN, DELETE_AFTER_IN_DAYS, ES_ENDPOINT } = process.env;

exports.handler = async function (event, context) {
  console.log(`Config: ES_ENDPOINT=${ES_ENDPOINT} INDEX_NAME_PATTERN=${INDEX_NAME_PATTERN} DELETE_AFTER_IN_DAYS=${DELETE_AFTER_IN_DAYS}`);
  const today = DateTime.local().startOf('day');
  const duration = Duration.fromObject({ days: DELETE_AFTER_IN_DAYS });
  const limitDate = today.minus(duration);
  const indices = await listIndices();

  console.log(`Listed ${indices.length} indices [${indices.map(i => i.index).join(' ')}]`);

  const indicesToDelete = indices
    .filter(i => {
      const indexDate = DateTime.fromFormat(i.index, INDEX_NAME_PATTERN);
      if (!indexDate.isValid) {
        console.error(`Failed to format ${i.index} using pattern ${INDEX_NAME_PATTERN}`)
        return false;
      }
      return indexDate < limitDate;
    });

  console.log(`Deleting ${indicesToDelete.length} indices [${indicesToDelete.map(i => i.index).join(' ')}]`);

  await Promise.all(indicesToDelete.map(deleteIndex));

  return 'DONE';
};

function throwError (message, data) {
  console.error(message, data);
  throw new Error(message);
}

async function listIndices () {
  const { statusCode, body } = await request('GET', '/_cat/indices?format=json');
  if (statusCode !== 200) {
    throwError('Failed to list indices', body);
  } else {
    return JSON.parse(body);
  }
}

async function deleteIndex ({ index }) {
  const { statusCode, body } = await request('DELETE', `/${index}?format=json`);
  if (statusCode !== 200) {
    throwError('Failed to delete index', body);
  } else {
    console.log(`Index ${index} was deleted with success`);
    return body;
  }
}

function request (method, path, body = '') {
  const signedParams = aws4.sign({
    host: ES_ENDPOINT,
    path,
    method,
    body
  });

  return new Promise((resolve, reject) => {
    const req = https.request(signedParams, (res) => {
      let responseBody = '';
      res.on('data', chunk => { responseBody += chunk; });
      res.on('end', () => {
        res.body = responseBody;
        resolve(res);
      });
      res.on('error', error => reject(error));
    });
    req.end(signedParams.body);
  });
}
