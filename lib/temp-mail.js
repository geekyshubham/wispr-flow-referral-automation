// Temp mail helpers using mail.tm API (usable inside ego-browser heredocs via serverFetch)

async function getMailDomain() {
  const resp = await serverFetch('https://api.mail.tm/domains');
  const data = JSON.parse(resp);
  return data['hydra:member'][0].domain;
}

async function createTempEmail() {
  const domain = await getMailDomain();
  const username = 'flow' + Math.floor(Math.random() * 900000 + 100000);
  const email = `${username}@${domain}`;
  const password = 'FlowTest2026!';

  await serverFetch('https://api.mail.tm/accounts', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ address: email, password }),
  });

  const tokenResp = await serverFetch('https://api.mail.tm/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ address: email, password }),
  });
  const tokenData = JSON.parse(tokenResp);

  return { email, password, mailToken: tokenData.token };
}

async function waitForVerificationLink(mailToken, maxAttempts = 30) {
  for (let i = 0; i < maxAttempts; i++) {
    await wait(2);
    const msgsResp = await serverFetch('https://api.mail.tm/messages', {
      headers: { Authorization: `Bearer ${mailToken}` },
    });
    const msgs = JSON.parse(msgsResp);
    if (msgs['hydra:totalItems'] > 0) {
      const msgId = msgs['hydra:member'][0].id;
      const msgResp = await serverFetch(`https://api.mail.tm/messages/${msgId}`, {
        headers: { Authorization: `Bearer ${mailToken}` },
      });
      const msg = JSON.parse(msgResp);
      const html = typeof msg.html === 'string' ? msg.html : String(msg.text || '');
      const links = [...html.matchAll(/href="(https:\/\/[^"]+)"/g)].map((m) => m[1]);
      const verifyLink = links.find(
        (l) => l.includes('auth.wisprflow.com') && l.includes('verify')
      );
      if (verifyLink) return verifyLink.replace(/&amp;/g, '&');
    }
  }
  return null;
}

async function waitForOtpCode(mailToken, maxAttempts = 30) {
  for (let i = 0; i < maxAttempts; i++) {
    await wait(2);
    const msgsResp = await serverFetch('https://api.mail.tm/messages', {
      headers: { Authorization: `Bearer ${mailToken}` },
    });
    const msgs = JSON.parse(msgsResp);
    if (msgs['hydra:totalItems'] > 0) {
      const msgId = msgs['hydra:member'][0].id;
      const msgResp = await serverFetch(`https://api.mail.tm/messages/${msgId}`, {
        headers: { Authorization: `Bearer ${mailToken}` },
      });
      const msg = JSON.parse(msgResp);
      const text = (msg.text || '') + (typeof msg.html === 'string' ? msg.html : '');
      const match = text.match(/\b(\d{6})\b/);
      if (match) return match[1];
    }
  }
  return null;
}
