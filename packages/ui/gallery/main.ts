import '@21n/fonts/styles.css';
import '../src/styles/base.css';
import '../src/styles/schemes.css';
import { mount } from 'svelte';
import Gallery from './Gallery.svelte';

mount(Gallery, { target: document.getElementById('app')! });
