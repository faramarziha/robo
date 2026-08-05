document.querySelector('.auth-form').addEventListener('submit', function () {
    document.getElementById('loginText').style.display = 'none';
    document.getElementById('loginSpin').style.display = 'inline-block';
    document.getElementById('loginBtn').disabled = true;
});

window.togglePw = function (id, btn) {
    var inp = document.getElementById(id);
    if (!inp) return;
    if (inp.type === 'password') {
        inp.type = 'text';
        btn.style.color = 'var(--ac)';
    } else {
        inp.type = 'password';
        btn.style.color = 'var(--dim)';
    }
};
