// Test helper: a minimal eSCL scanner that hands out the given JPEG files as
// one ADF job, then answers 404 (job complete). Writes its port to <portfile>.
//   bun fake-escl.ts <portfile> <page.jpg>...
import { writeFileSync } from "node:fs";

const [portFile, ...pages] = process.argv.slice(2);
let next = 0;
let loaded = true;

const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === "/eSCL/ScannerStatus") {
      const adf = loaded ? "ScannerAdfLoaded" : "ScannerAdfEmpty";
      return new Response(
        `<scan:ScannerStatus><pwg:State>Idle</pwg:State><scan:AdfState>${adf}</scan:AdfState></scan:ScannerStatus>`);
    }
    if (path === "/eSCL/ScanJobs" && req.method === "POST") {
      return new Response(null, { status: 201, headers: { Location: "/eSCL/ScanJobs/1" } });
    }
    if (path === "/eSCL/ScanJobs/1/NextDocument") {
      if (next >= pages.length) { loaded = false; return new Response(null, { status: 404 }); }
      return new Response(Bun.file(pages[next++]), { headers: { "Content-Type": "image/jpeg" } });
    }
    if (path === "/eSCL/ScanJobs/1" && req.method === "DELETE") return new Response(null, { status: 200 });
    return new Response(null, { status: 404 });
  },
});
writeFileSync(portFile, String(server.port));
