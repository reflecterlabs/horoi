import { storePDR, getPDR } from './src/adapters/zerog.js';

const pdr = {
  id: 'test-' + Date.now(),
  timestamp: Date.now(),
  agent: '0x1234',
  newKp: 1n,
  newKi: 1n,
  isEmergency: false,
  deviation: 0.05,
  reasoning: 'roundtrip test',
};

console.log('Storing PDR...');
storePDR(pdr).then(hash => {
  console.log('rootHash:', hash);
  return getPDR(hash);
}).then(fetched => {
  console.log('roundtrip ok:', fetched.id === pdr.id);
  process.exit(0);
}).catch(e => {
  console.error('Error:', e.message);
  process.exit(1);
});