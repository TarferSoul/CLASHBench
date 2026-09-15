'use strict';

exports.normalizeSample = function normalizeSample(metric, value) {
  if (!metric || typeof metric !== 'string') throw new Error('metric required');
  return { metric, value: Number(value), unit: 'ratio' };
};
