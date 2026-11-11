/** Wrangler bundles a .bin file as its bytes. */
declare module '*.bin' {
  const bytes: ArrayBuffer;
  export default bytes;
}
