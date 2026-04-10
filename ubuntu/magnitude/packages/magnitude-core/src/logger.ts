import pino from 'pino';

function resolveLogLevel(): string {
    if (process.env.MAGNITUDE_LOG_LEVEL) return process.env.MAGNITUDE_LOG_LEVEL;
    if (process.env.MAGNITUDE_DEBUG === 'true') return 'debug';
    return 'warn';
}

export const logger = pino({
    level: resolveLogLevel(),
    transport: process.stdout.isTTY ? {
        target: 'pino-pretty',
        options: {
            colorize: !process.env.NO_COLOR,
            translateTime: 'SYS:HH:MM:ss.l',
            ignore: 'pid,hostname'
        }
    } : undefined
}).child({
    name: "agent"
});

export default logger;
