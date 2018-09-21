const https = require('https');
const zlib = require('zlib');
const aws4 = require('./aws4');
const { DateTime } = require('./luxon');
const { INDEX_NAME_PATTERN, ES_ENDPOINT } = process.env;

exports.handler = async function (event, context) {
  const zippedData = new Buffer(event.awslogs.data, 'base64');
  const data = await decompress(zippedData);
  const payload = JSON.parse(data);

  if (payload.messageType !== 'DATA_MESSAGE') {
    console.log(`Received ${payload.messageType} messageType. Ignoring.`);
    context.succeed('Success');
    return;
  }

  try {
    await sendLogsToES(payload);
  } catch (error) {
    console.error('Exception', error);
    context.fail('Failed');
    throw error;
  }

  context.succeed('Success');
}

function decompress (input) {
  return new Promise((resolve, reject) => {
    zlib.gunzip(input, (error, buffer) => {
      if (error) {
        reject(error);
      } else {
        resolve(buffer.toString('utf8'));
      }
    });
  });
}

async function sendLogsToES (payload) {
  const requestBody = parseToBulkRequestBody(payload);
  console.log('Sending logs to ES', requestBody);
	const { statusCode, body } = await request('POST', `/_bulk`, requestBody);
  if (statusCode >= 200 && statusCode < 300) {
    console.log('Logs sent to ES', body);
  } else {
    console.error('Failed to send logs to ES', body);
    throw new Error('Request to ES failed');
  }
}

function parseToBulkRequestBody (payload) {
  return payload.logEvents.map(logEvent => {
    const timestamp = DateTime.fromMillis(Number(logEvent.timestamp));
    const indexName = timestamp.toFormat(INDEX_NAME_PATTERN);

    const logBody = extractJSONFromLogMessage(logEvent.message)[0];

    const log = JSON.stringify({
      ...logBody,
      '@id': logEvent.id,
      '@timestamp': timestamp.toUTC().toISO(),
      '@message': logEvent.message,
      '@owner': payload.owner,
      '@log_group': payload.logGroup,
      '@log_stream': payload.logStream
    });

    const action = JSON.stringify({
      index: {
        '_index': indexName,
        '_type': 'log',
        '_id': logEvent.id
      }
    });

    return `${action}\n${log}\n`;
  }).join('');
}

function extractJSONFromLogMessage (message) {
  const messageParts = message.split('\t');
  return messageParts
    .map(m => m.trim())
    .filter(m => m.startsWith('{') && m.endsWith('}'))
    .filter(m => isValidJSON(m))
    .map(m => JSON.parse(m))
    .map(o => addRawIndicesToObject(o));
}

function isValidJSON (str) {
  try {
    JSON.parse(str);
    return true;
  } catch (e) {
    return false;
  }
}

function addRawIndicesToObject (obj) {
  Object.keys(obj).forEach(key => {
    if (String(obj[key]) !== '[object Object]') {
      return;
    }

    obj[`_${key}`] = JSON.stringify(obj[key]);
    addRawIndicesToObject(obj[key]);
  });

  return obj;
}

function request (method, path, body = '') {
	const signedParams = aws4.sign({
		host: ES_ENDPOINT,
		path,
		method,
    headers: {
      'Content-Type': 'application/json'
    },
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
