"use strict";

const fs = require("node:fs");
const path = require("node:path");

async function main() {
    const [sdkDir, webappsBuildDir, expectedVersion, ...extra] = process.argv.slice(2);
    if (!sdkDir || !webappsBuildDir || !expectedVersion || extra.length) {
        throw new Error("ОШИБКА: использование: sdk-minify.cjs <каталог deploy SDK> <каталог build web-apps> <версия Terser>");
    }

    if (!/^5\.[0-9]+\.[0-9]+$/.test(expectedVersion)) {
        throw new Error(`ОШИБКА: ожидалась версия Terser вида 5.<число>.<число>, получено ${expectedVersion}`);
    }

    // The version is pinned by the calling script; this step does not download packages.
    const terserDir = path.resolve(webappsBuildDir, "node_modules/terser");
    const { version } = require(path.join(terserDir, "package.json"));
    if (!/^5\.[0-9]+\.[0-9]+$/.test(version) || version !== expectedVersion) {
        throw new Error(`ОШИБКА: ожидался Terser ${expectedVersion}, найден ${version}`);
    }
    const terser = require(terserDir);
    const files = ["word", "cell", "slide"].flatMap(product =>
        ["sdk-all-min.js", "sdk-all.js"].map(name => path.resolve(sdkDir, product, name))
    );
    for (const file of files) {
        if (!fs.existsSync(file) || !fs.statSync(file).isFile() || fs.statSync(file).size === 0) {
            throw new Error(`ОШИБКА: отсутствует или пуст SDK: ${file}`);
        }
    }

    const results = [];
    for (const file of files) {
        const source = fs.readFileSync(file, "utf8");
        const { code } = await terser.minify(source, {
            compress: false,
            mangle: false,
            format: { comments: /@preserve|@license|@cc_on|^!|Copyright|GNU|Affero|AGPL|licen[cs]e/i }
        });
        if (!code) {
            throw new Error(`ОШИБКА: пустой результат минификации: ${file}`);
        }
        const notices = text => (text.match(/Copyright|Affero/gi) || []).length;
        if (notices(code) < notices(source)) {
            throw new Error(`ОШИБКА: число лицензионных уведомлений уменьшилось: ${file}`);
        }
        results.push({ file, source, code });
    }

    // Writing starts only after all six results have been checked.
    for (const { file, source, code } of results) {
        fs.writeFileSync(file, code);
        console.log(`${path.relative(sdkDir, file)}: ${Buffer.byteLength(source)} -> ${Buffer.byteLength(code)} bytes`);
    }
    console.log(`sdk-minify: terser=${version}`);
}

main().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
});
