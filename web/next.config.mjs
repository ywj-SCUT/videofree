/** @type {import('next').NextConfig} */
const nextConfig = {
  experimental: { externalDir: true },
  webpack(config) {
    config.resolve.extensionAlias = { ...config.resolve.extensionAlias, '.js': ['.ts', '.js'] };
    return config;
  },
};

export default nextConfig;
