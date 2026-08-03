'use client';

import App from '../../src/App';
import { installWebApi } from '../lib/client-api';

installWebApi();

export default function WebClient() {
  return <div className="web-host"><App /></div>;
}
