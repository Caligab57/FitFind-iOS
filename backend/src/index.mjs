import {loadConfig} from './config.mjs';
import {createService} from './server.mjs';

try {
  const config=loadConfig();
  const server=createService(config);
  server.on('error',()=>{console.error('Could not start the service. Check HOST and PORT.');process.exitCode=1;});
  server.listen(config.port,config.host,()=>{
    console.log(JSON.stringify({event:'listening',host:config.host,port:config.port,ready:!!config.apiKey}));
  });
  let closing=false;
  function shutdown() {
    if(closing) return; closing=true;
    server.close(()=>process.exit(0));
    setTimeout(()=>{server.closeAllConnections();process.exit(0);},5000).unref();
  }
  process.on('SIGINT',shutdown);process.on('SIGTERM',shutdown);
} catch(error) {
  console.error(error.message);process.exitCode=1;
}
