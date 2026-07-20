declare module "qrcode-terminal" {
  const qrcode: {
    generate(input: string, options: { small?: boolean }, callback: (rendered: string) => void): void;
  };
  export default qrcode;
}
