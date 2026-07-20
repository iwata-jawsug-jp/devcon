export { apiClient, ApiClient, ApiError } from './client';
//export type { HealthResponse, ApiPaths } from './client'; 既存ソースをコメントアウト
export type { paths } from './schema';
//export { useHealthQuery } from './queries'; 既存ソースをコメントアウト
export type { HealthResponse, GreetingResponse, ApiPaths } from './client';
export { useHealthQuery, useGreetingQuery } from './queries';
