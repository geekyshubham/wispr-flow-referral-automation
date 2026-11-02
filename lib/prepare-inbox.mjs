import { prepareInbox } from './web-auth.mjs';

try { await prepareInbox(process.argv[2], undefined, process.argv[3] || 'maildrop'); }
catch (error) { console.error('ERROR:' + error.message); process.exitCode = 1; }
