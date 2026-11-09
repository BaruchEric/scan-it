// Test helper: damage a restart-marker JPEG the two ways the Brother does.
//   bun jpeg-cut.ts truncate <in> <out> <N>   keep N restart markers, then end
//   bun jpeg-cut.ts drop <in> <out> <K>       cut out the rows between marker K
//                                             and marker K+2 (sequence skips)
import { readFileSync, writeFileSync } from "node:fs";

const [mode, input, output, nArg] = process.argv.slice(2);
const buf = readFileSync(input);
const n = Number(nArg);

const sos = buf.indexOf(Buffer.from([0xff, 0xda]));
if (sos < 0) throw new Error("no SOS marker");
const scan = sos + 2 + buf.readUInt16BE(sos + 2);
const markers: number[] = [];
for (let j = scan; j + 1 < buf.length; j++) {
  if (buf[j] === 0xff && buf[j + 1] >= 0xd0 && buf[j + 1] <= 0xd7) markers.push(j);
}
const eoi = Buffer.from([0xff, 0xd9]);

if (mode === "truncate") {
  // Data up to, but not including, marker N+1: N markers and part of a row.
  writeFileSync(output, Buffer.concat([buf.subarray(0, markers[n]), eoi]));
} else if (mode === "drop") {
  writeFileSync(output, Buffer.concat([buf.subarray(0, markers[n]), buf.subarray(markers[n + 2])]));
} else {
  throw new Error(`unknown mode ${mode}`);
}
