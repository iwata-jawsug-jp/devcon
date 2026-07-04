import js from '@eslint/js';
import pluginVue from 'eslint-plugin-vue';
import vueTsConfig from '@vue/eslint-config-typescript';
import prettierConfig from 'eslint-config-prettier';
import globals from 'globals';

export default [
  {
    ignores: [
      'dist/**',
      'node_modules/**',
      'playwright-report/**',
      'coverage/**',
      'src/api/schema.ts',
    ],
  },
  js.configs.recommended,
  ...pluginVue.configs['flat/recommended'],
  ...vueTsConfig(),
  {
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: {
        ...globals.browser,
        ...globals.node,
      },
    },
  },
  // 整形は prettier、品質は eslint に責務分離する（#214）。
  // prettier の整形結果と衝突する整形系ルール（vue/* 含む）を無効化するため、必ず配列の最後に置く。
  prettierConfig,
];
